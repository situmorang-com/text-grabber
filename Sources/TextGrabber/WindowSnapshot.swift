import AppKit

/// Renders one of the app's own windows to a PNG, for checking a layout without looking at the screen.
/// It draws the window's views directly, so it needs no Screen Recording access and works while the
/// screen is locked or the display is asleep.
enum WindowSnapshot {
    /// `textgrabber://snapshot?window=<name>` names: the window's title.
    static let titles = [
        "setup": "Set Up TextGrabber",
        "settings": "TextGrabber Settings",
        "history": "Capture History",
        "editor": "Captured Text",
        // Shown by textgrabber://demo?card=…, never with a title bar.
        "hud": "TextGrabber Notice",
        "codes": "TextGrabber Code Confirmation",
    ]

    /// Set while a window is opened for a snapshot: it is shown without taking focus from the user's app.
    static var isTaking = false

    static func window(named name: String) -> NSWindow? {
        guard let title = titles[name] else { return nil }
        return NSApp.windows.first { $0.title == title && $0.isVisible }
    }

    static func file(for name: String) -> URL {
        AccessibilityText.logFile.deletingLastPathComponent().appendingPathComponent("snapshot-\(name).png")
    }

    /// Writes the PNG and a short account to the capture log: where the window is, and whether its content fits.
    static func write(name: String) {
        guard let title = titles[name] else {
            AccessibilityText.writeLog("snapshot: unknown window \"\(name)\"; known: \(titles.keys.sorted().joined(separator: ", "))\n")
            return
        }
        guard let window = window(named: name), let content = window.contentView else {
            AccessibilityText.writeLog("snapshot \(name): no visible window titled \"\(title)\"\n")
            return
        }
        // The frame view holds the title bar as well as the content.
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            AccessibilityText.writeLog("snapshot \(name): the window could not be drawn\n")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = file(for: name)
        var report = "snapshot \(name)\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            report += "file: \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh) px)\n"
        } catch {
            report += "file not written: \(error.localizedDescription)\n"
        }
        let frame = window.frame
        report += "window: \(Int(frame.width))×\(Int(frame.height)) pt at \(Int(frame.minX)),\(Int(frame.minY))"
        report += window.screen.map { " on \($0.localizedName)" } ?? " on no screen (off-screen)"
        report += "\n"
        let needed = content.fittingSize
        let has = content.bounds.size
        if needed.width > has.width + 1 || needed.height > has.height + 1 {
            report += "content does NOT fit: needs \(Int(needed.width))×\(Int(needed.height)) pt, has \(Int(has.width))×\(Int(has.height))\n"
        } else {
            report += "content fits: needs \(Int(needed.width))×\(Int(needed.height)) pt, has \(Int(has.width))×\(Int(has.height))\n"
        }
        AccessibilityText.writeLog(report)
    }
}
